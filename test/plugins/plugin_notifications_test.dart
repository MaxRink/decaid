import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/notifications/native_notification.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_notifications.dart';

void main() {
  test(
    'validates plugin text, one approved action and credential-free HTTPS',
    () {
      final invalid = <dynamic>[
        null,
        {'id': '', 'message': 'Message'},
        {'id': 'a', 'message': ''},
        {'id': 'a', 'message': 'x' * 601},
        {
          'id': 'a',
          'message': 'Message',
          'action': {'type': 'execute'},
        },
        for (final type in [
          'downloadUpdate',
          'skipUpdate',
          'openDecentAccount',
        ])
          {
            'id': 'a',
            'message': 'Message',
            'action': {'id': 'action', 'label': 'Open', 'type': type},
          },
        for (final url in [
          'javascript:alert(1)',
          'file:///tmp/file',
          'http://example.com/',
          'https://user:secret@example.com/',
          'https:///relative',
        ])
          {
            'id': 'a',
            'message': 'Message',
            'action': {
              'id': 'link',
              'label': 'Open',
              'type': 'openExternalUrl',
              'url': url,
            },
          },
      ];
      for (final payload in invalid) {
        expect(
          () => parsePluginNotification(
            pluginId: 'first',
            pluginName: 'First',
            payload: payload,
            canOpenAccount: false,
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('account actions also require the account proxy permission', () {
    final notice = parsePluginNotification(
      pluginId: 'first',
      pluginName: 'First',
      payload: {
        'id': 'account',
        'message': 'Sign in',
        'action': {
          'id': 'signIn',
          'label': 'Sign In',
          'type': 'openDecentAccount',
        },
      },
      canOpenAccount: true,
    );
    expect(notice.actions.single.id, 'signIn');
    expect(notice.sourceId, 'first');
  });

  group('openPluginSurface', () {
    final manifest = PluginManifest.fromJson({
      'id': 'e64',
      'name': 'E64',
      'version': '1.0.0',
      'apiVersion': 1,
      'settings': <String, dynamic>{},
      'author': 'Test',
      'description': 'Test',
      'permissions': ['api', 'notifications'],
      'api': [
        for (final id in ['setup', 'device-settings'])
          {'id': id, 'type': 'http', 'data': <String, dynamic>{}},
      ],
      'surfaces': [
        {'id': 'setup', 'role': 'setup', 'endpoint': 'setup'},
      ],
      'drivers': [
        {
          'id': 'grinder',
          'type': 'grinder',
          'surfaces': [
            {
              'id': 'device-settings',
              'role': 'settings',
              'endpoint': 'device-settings',
            },
          ],
        },
      ],
    });

    NativeNotification parse(Map<String, dynamic> action) =>
        parsePluginNotification(
          pluginId: 'e64',
          pluginName: 'E64',
          payload: {
            'id': 'setup',
            'message': 'E64 needs setup',
            'action': {'id': 'open', 'label': 'Set up', ...action},
          },
          canOpenAccount: false,
          manifest: manifest,
        );

    test('resolves a declared plugin surface by id or endpoint', () {
      for (final action in [
        {'type': 'openPluginSurface', 'surfaceId': 'setup'},
        {'type': 'openPluginSurface', 'pluginId': 'e64', 'endpoint': 'setup'},
      ]) {
        final resolved = parse(action).actions.single;
        expect(resolved.type, NotificationActionType.openPluginSurface);
        expect(resolved.href, '/api/v1/plugins/e64/setup?ui=1&surface=setup');
        expect(resolved.url, isNull);
      }
    });

    test('resolves a driver surface for a device', () {
      final resolved = parse({
        'type': 'openPluginSurface',
        'surfaceId': 'device-settings',
        'deviceId': 'grinder 1',
      }).actions.single;
      expect(
        resolved.href,
        '/api/v1/plugins/e64/device-settings?ui=1&deviceId=grinder+1',
      );
    });

    test('rejects undeclared, foreign or ambiguous targets', () {
      for (final action in [
        {'type': 'openPluginSurface', 'surfaceId': 'missing'},
        {'type': 'openPluginSurface', 'endpoint': 'device-settings'},
        {'type': 'openPluginSurface', 'surfaceId': 'setup', 'deviceId': 'x'},
        {
          'type': 'openPluginSurface',
          'pluginId': 'other',
          'surfaceId': 'setup',
        },
        {'type': 'openPluginSurface'},
        {
          'type': 'openPluginSurface',
          'surfaceId': 'setup',
          'endpoint': 'setup',
        },
        {
          'type': 'openPluginSurface',
          'surfaceId': 'device-settings',
          'deviceId': '',
        },
        {
          'type': 'openPluginSurface',
          'surfaceId': 'setup',
          'url': 'https://example.com/',
        },
      ]) {
        expect(() => parse(action), throwsFormatException, reason: '$action');
      }
    });

    test('without a manifest the action is not permitted', () {
      expect(
        () => parsePluginNotification(
          pluginId: 'e64',
          pluginName: 'E64',
          payload: {
            'id': 'setup',
            'message': 'Needs setup',
            'action': {
              'id': 'open',
              'label': 'Set up',
              'type': 'openPluginSurface',
              'surfaceId': 'setup',
            },
          },
          canOpenAccount: false,
        ),
        throwsFormatException,
      );
    });

    test('resolved hrefs survive persistence and reject foreign targets', () {
      final notice = parse({'type': 'openPluginSurface', 'surfaceId': 'setup'})
          .withState(revision: 1);
      final restored = NativeNotification.fromJson(notice.toJson());
      expect(restored.actions.single.href, notice.actions.single.href);

      for (final href in [
        'https://evil.example/api/v1/plugins/e64/setup',
        '//evil.example/api/v1/plugins/e64/setup',
        '/api/v1/machine/state',
        null,
      ]) {
        final json = notice.toJson();
        (json['actions'] as List).first = {
          'id': 'open',
          'label': 'Set up',
          'type': 'openPluginSurface',
          'href': ?href,
        };
        expect(
          () => NativeNotification.fromJson(json),
          throwsFormatException,
          reason: '$href',
        );
      }
    });
  });
}
