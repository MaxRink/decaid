import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_device_surface_authority.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

Map<String, dynamic> manifestJson({
  Object? surfaces,
  List<String> permissions = const ['api'],
  List<String> endpoints = const ['setup', 'diag', 'prefs'],
  String id = 'surface.owner',
}) => {
  'id': id,
  'name': 'Surface owner',
  'version': '1.0.0',
  'apiVersion': 1,
  'settings': <String, dynamic>{},
  'author': 'Test',
  'description': 'Plugin-level surfaces',
  'permissions': permissions,
  'api': [
    for (final endpoint in endpoints)
      {'id': endpoint, 'type': 'http', 'data': <String, dynamic>{}},
    {'id': 'events', 'type': 'websocket', 'data': <String, dynamic>{}},
  ],
  'surfaces': ?surfaces,
};

void main() {
  const validSurfaces = [
    {'id': 'setup', 'role': 'setup', 'endpoint': 'setup', 'label': 'Set up'},
    {'id': 'settings', 'role': 'settings', 'endpoint': 'prefs'},
    {'id': 'diagnostics', 'role': 'diagnostics', 'endpoint': 'diag'},
  ];

  test('parses setup, settings and diagnostics surfaces', () {
    final manifest = PluginManifest.fromJson(
      manifestJson(surfaces: validSurfaces),
    );

    expect(manifest.surfaces.map((surface) => surface.role), [
      'setup',
      'settings',
      'diagnostics',
    ]);
    expect(manifest.toJson()['surfaces'], validSurfaces);
    expect(
      PluginManifest.fromJson(manifest.toJson()).surfaces.length,
      validSurfaces.length,
    );
  });

  test('a manifest without surfaces is unchanged', () {
    final manifest = PluginManifest.fromJson(manifestJson());

    expect(manifest.surfaces, isEmpty);
    expect(manifest.toJson().containsKey('surfaces'), isFalse);
  });

  final invalid = <String, Map<String, dynamic>>{
    'not an array': manifestJson(surfaces: {'id': 'setup'}),
    'unknown role': manifestJson(
      surfaces: [
        {'id': 'x', 'role': 'wizard', 'endpoint': 'setup'},
      ],
    ),
    'duplicate setup': manifestJson(
      surfaces: [
        {'id': 'a', 'role': 'setup', 'endpoint': 'setup'},
        {'id': 'b', 'role': 'setup', 'endpoint': 'prefs'},
      ],
    ),
    'duplicate settings': manifestJson(
      surfaces: [
        {'id': 'a', 'role': 'settings', 'endpoint': 'setup'},
        {'id': 'b', 'role': 'settings', 'endpoint': 'prefs'},
      ],
    ),
    'duplicate id': manifestJson(
      surfaces: [
        {'id': 'a', 'role': 'setup', 'endpoint': 'setup'},
        {'id': 'a', 'role': 'diagnostics', 'endpoint': 'diag'},
      ],
    ),
    'undeclared endpoint': manifestJson(
      surfaces: [
        {'id': 'setup', 'role': 'setup', 'endpoint': 'missing'},
      ],
    ),
    'websocket endpoint': manifestJson(
      surfaces: [
        {'id': 'setup', 'role': 'setup', 'endpoint': 'events'},
      ],
    ),
    'reserved host route': manifestJson(
      endpoints: ['settings'],
      surfaces: [
        {'id': 'setup', 'role': 'setup', 'endpoint': 'settings'},
      ],
    ),
    'missing api permission': manifestJson(
      permissions: const [],
      surfaces: [
        {'id': 'setup', 'role': 'setup', 'endpoint': 'setup'},
      ],
    ),
    'extra key': manifestJson(
      surfaces: [
        {
          'id': 'setup',
          'role': 'setup',
          'endpoint': 'setup',
          'href': 'https://evil.example/',
        },
      ],
    ),
    'too many': manifestJson(
      surfaces: [
        for (var i = 0; i < 9; i++)
          {'id': 'd$i', 'role': 'diagnostics', 'endpoint': 'diag'},
      ],
    ),
  };
  for (final entry in invalid.entries) {
    test('rejects ${entry.key}', () {
      expect(
        () => PluginManifest.fromJson(entry.value),
        throwsA(isA<FormatException>()),
      );
    });
  }

  test('driver surfaces still reject the setup role', () {
    expect(
      () => PluginDeviceSurface.fromJson({
        'id': 'setup',
        'role': 'setup',
        'endpoint': 'setup',
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('links resolve to same-origin plugin endpoints without a device', () {
    final manifest = PluginManifest.fromJson(
      manifestJson(id: 'surface owner', surfaces: validSurfaces),
    );

    expect(pluginSurfaceLinks(manifest), [
      {
        'id': 'setup',
        'role': 'setup',
        'label': 'Set up',
        'href': '/api/v1/plugins/surface%20owner/setup?ui=1&surface=setup',
      },
      {
        'id': 'settings',
        'role': 'settings',
        'href': '/api/v1/plugins/surface%20owner/prefs?ui=1&surface=settings',
      },
      {
        'id': 'diagnostics',
        'role': 'diagnostics',
        'href': '/api/v1/plugins/surface%20owner/diag?ui=1&surface=diagnostics',
      },
    ]);
  });
}
