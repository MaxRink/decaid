import 'package:collection/collection.dart';

import '../notifications/native_notification.dart';
import 'plugin_device_surface_authority.dart';
import 'plugin_manifest.dart';

NativeNotification parsePluginNotification({
  required String pluginId,
  required String pluginName,
  required dynamic payload,
  required bool canOpenAccount,
  PluginManifest? manifest,
}) {
  if (payload is! Map) throw const FormatException('Invalid notification');
  final rawAction = payload['action'];
  final NotificationAction? action;
  if (rawAction == null) {
    action = null;
  } else {
    if (rawAction is! Map) {
      throw const FormatException('Invalid notification action');
    }
    final type = rawAction['type'];
    if (type == 'openPluginSurface' && manifest != null) {
      action = NotificationAction(
        id: notificationText(rawAction['id'], 128),
        label: notificationText(rawAction['label'], 40),
        type: NotificationActionType.openPluginSurface,
        href: resolvePluginSurfaceAction(manifest, rawAction),
      );
    } else if (type != 'openExternalUrl' &&
        !(type == 'openDecentAccount' && canOpenAccount)) {
      throw const FormatException('Notification action is not permitted');
    } else {
      action = NotificationAction.fromJson(
        Map<String, dynamic>.from(rawAction),
      );
    }
  }
  return NativeNotification(
    namespace: NotificationNamespace.plugin,
    sourceId: notificationText(pluginId, 128),
    sourceName: notificationText(pluginName, 256),
    id: notificationText(payload['id'], 128),
    message: notificationText(payload['message'], 600),
    actions: action == null ? const [] : [action],
  );
}

String resolvePluginSurfaceAction(PluginManifest manifest, Map action) {
  const allowedKeys = {
    'id',
    'label',
    'type',
    'pluginId',
    'surfaceId',
    'endpoint',
    'deviceId',
  };
  final surfaceId = action['surfaceId'];
  final endpoint = action['endpoint'];
  final deviceId = action['deviceId'];
  if (action.keys.any((key) => !allowedKeys.contains(key)) ||
      (action.containsKey('pluginId') && action['pluginId'] != manifest.id) ||
      (surfaceId == null) == (endpoint == null) ||
      (surfaceId != null && surfaceId is! String) ||
      (endpoint != null && endpoint is! String)) {
    throw const FormatException('Invalid plugin surface action');
  }
  bool matches(PluginDeviceSurface surface) => surfaceId != null
      ? surface.id == surfaceId
      : surface.endpoint == endpoint;
  if (deviceId == null) {
    final surface = manifest.surfaces.firstWhereOrNull(matches);
    if (surface == null) {
      throw const FormatException('Undeclared plugin surface');
    }
    return pluginSurfaceHref(manifest.id, surface);
  }
  final surface = manifest.drivers
      .expand((driver) => driver.surfaces)
      .firstWhereOrNull(matches);
  if (surface == null) {
    throw const FormatException('Undeclared plugin device surface');
  }
  return PluginDeviceSurfaceAuthority(
    pluginId: manifest.id,
    surfaces: [surface],
  ).resolve(notificationText(deviceId, 256)).single['href']!;
}

String? pluginSetupReason(
  PluginManifest manifest,
  Iterable<NativeNotification> notices,
) {
  final setup = manifest.surfaces.firstWhereOrNull(
    (surface) => surface.role == 'setup',
  );
  if (setup == null) return null;
  final href = pluginSurfaceHref(manifest.id, setup);
  return notices
      .firstWhereOrNull(
        (notice) =>
            notice.namespace == NotificationNamespace.plugin &&
            notice.sourceId == manifest.id &&
            notice.actions.any(
              (action) =>
                  action.type == NotificationActionType.openPluginSurface &&
                  action.href == href,
            ),
      )
      ?.message;
}
