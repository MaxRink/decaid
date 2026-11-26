import 'dart:async';
import 'dart:convert';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_discovery.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

const _grinder = PluginMdnsService(
  name: 'Mahlkoenig grinder E64 WS (HSG) family (hemrohsg3B2D6C)',
  host: 'hemrohsg3B2D6C.local',
  port: 443,
  addresses: ['192.168.200.103', 'fe80::1'],
  txt: {'grindername': 'HemroHsg-3B2D6C', 'serialno': '3B2D6C'},
);
const _printer = PluginMdnsService(
  name: 'Office printer',
  host: 'printer.local',
  port: 443,
);

Map<String, dynamic> _manifestJson({
  Object? discovery = const {
    'mdns': [
      {'type': '_https._tcp', 'namePrefix': 'Mahlkoenig grinder'},
    ],
  },
  List<String> permissions = const ['emit', 'network.tls'],
}) => {
  'id': 'e64.discovery',
  'name': 'E64',
  'author': 'Test',
  'description': 'Test',
  'version': '1.0.0',
  'apiVersion': 1,
  'permissions': permissions,
  'settings': <String, dynamic>{},
  'api': <Object>[],
  'discovery': ?discovery,
};

void main() {
  group('manifest discovery', () {
    test('parses declared mdns service types', () {
      final manifest = PluginManifest.fromJson(_manifestJson());
      expect(manifest.mdnsDiscovery.single.serviceType, '_https._tcp');
      expect(manifest.mdnsDiscovery.single.namePrefix, 'Mahlkoenig grinder');
      expect(
        PluginManifest.fromJson(_manifestJson(discovery: null)).mdnsDiscovery,
        isEmpty,
      );
      expect(
        PluginManifest.fromJson(_manifestJson(discovery: {'ssdp': <Object>[]}))
            .mdnsDiscovery,
        isEmpty,
        reason: 'unknown discovery kinds are left for future hosts',
      );
    });

    for (final invalid in <Object>[
      'mdns',
      {'mdns': <Object>[]},
      {
        'mdns': [
          {'type': 'https', 'namePrefix': 'x'},
        ],
      },
      {
        'mdns': [
          {'type': '_https._tcp', 'namePrefix': ' '},
        ],
      },
      {
        'mdns': [
          {'type': '_https._tcp'},
        ],
      },
      {
        'mdns': [
          {'type': '_https._tcp', 'namePrefix': 'x', 'extra': true},
        ],
      },
    ]) {
      test('rejects $invalid', () {
        expect(
          () => PluginManifest.fromJson(_manifestJson(discovery: invalid)),
          throwsFormatException,
        );
      });
    }
  });

  group('browse request', () {
    const declared = [
      PluginMdnsDeclaration(
        serviceType: '_https._tcp',
        namePrefix: 'Mahlkoenig grinder',
      ),
    ];

    test('defaults to the declared prefix and clamps the timeout', () {
      final request = resolvePluginDiscoveryRequest(declared, {
        'serviceType': '_https._tcp',
        'timeoutMs': 60000,
      });
      expect(request.namePrefixes, ['Mahlkoenig grinder']);
      expect(request.timeout, maxPluginDiscoveryTimeout);
      expect(
        resolvePluginDiscoveryRequest(declared, {
          'serviceType': '_https._tcp',
        }).timeout,
        defaultPluginDiscoveryTimeout,
      );
    });

    test('a narrower prefix is allowed, a different one is not', () {
      expect(
        resolvePluginDiscoveryRequest(declared, {
          'serviceType': '_https._tcp',
          'namePrefix': 'mahlkoenig grinder E64',
        }).namePrefixes,
        ['mahlkoenig grinder E64'],
      );
      for (final options in [
        {'serviceType': '_https._tcp', 'namePrefix': 'Office'},
        {'serviceType': '_ipp._tcp'},
        {'serviceType': '_https._tcp', 'timeoutMs': 'soon'},
        'not an object',
      ]) {
        expect(
          () => resolvePluginDiscoveryRequest(declared, options),
          throwsFormatException,
          reason: '$options',
        );
      }
    });
  });

  test('bonsoir services map IPv4 first, without the trailing dot', () {
    final service = PluginMdnsService.fromBonsoir(
      BonsoirService(
        name: 'Mahlkoenig grinder E64',
        type: '_https._tcp',
        port: 443,
        hostname: 'hemrohsg3B2D6C.local.',
        hostAddresses: const ['fe80::1', '192.168.200.103'],
        attributes: const {'serialno': '3B2D6C'},
      ),
    );
    expect(service.toJson(), {
      'name': 'Mahlkoenig grinder E64',
      'host': 'hemrohsg3B2D6C.local',
      'port': 443,
      'addresses': ['192.168.200.103', 'fe80::1'],
      'txt': {'serialno': '3B2D6C'},
    });
  });

  group('host.discovery.browse', () {
    late PluginManager manager;
    late List<({String type, Duration timeout})> browses;
    late Completer<void> release;

    setUp(() {
      browses = [];
      release = Completer<void>()..complete();
      manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        mdnsBrowser: (type, timeout, accepts) async {
          browses.add((type: type, timeout: timeout));
          await release.future;
          expect(accepts(_grinder.name), isTrue);
          expect(accepts(_printer.name), isFalse);
          return const [_printer, _grinder];
        },
      );
    });
    tearDown(() => manager.dispose());

    Future<Object?> run(String js, {Map<String, dynamic>? manifest}) async {
      final result = Completer<Object?>();
      final sub = manager.emitStream.listen((event) {
        if (!result.isCompleted) result.complete(event['payload']);
      });
      addTearDown(sub.cancel);
      await manager.loadPlugin(
        id: 'e64.discovery',
        manifest: PluginManifest.fromJson(manifest ?? _manifestJson()),
        settings: {},
        jsCode:
            '''
          function createPlugin(host) {
            const report = (value) => host.emit("result", JSON.stringify(value));
            const fail = (e) => report({ error: e.message, code: e.code });
            return { id: "e64.discovery", onLoad() { $js } };
          }
        ''',
      );
      return jsonDecode(
        await result.future.timeout(const Duration(seconds: 5)) as String,
      );
    }

    test('returns only declared, matching services', () async {
      final result = await run(
        'host.discovery.browse({ serviceType: "_https._tcp", '
        'namePrefix: "Mahlkoenig grinder", timeoutMs: 1500 })'
        '.then(report, fail);',
      );

      expect(result, [_grinder.toJson()]);
      expect(browses.single.type, '_https._tcp');
      expect(browses.single.timeout, const Duration(milliseconds: 1500));
    });

    test('an undeclared service type is refused without browsing', () async {
      final result = await run(
        'host.discovery.browse({ serviceType: "_ipp._tcp" }).then(report, fail);',
      );

      expect(result, containsPair('code', 'validation'));
      expect(browses, isEmpty);
    });

    test('a plugin without api or network permission is refused', () async {
      final result = await run(
        'host.discovery.browse({ serviceType: "_https._tcp" }).then(report, fail);',
        manifest: _manifestJson(permissions: const ['emit']),
      );

      expect(result, containsPair('code', 'permission'));
      expect(browses, isEmpty);
    });

    test('one browse runs at a time per plugin', () async {
      release = Completer<void>();
      final result = run('''
        const options = { serviceType: "_https._tcp" };
        const first = host.discovery.browse(options);
        host.discovery.browse(options).then(
          () => report({ second: "resolved" }),
          (e) => first.then((services) => report({ code: e.code, first: services.length }))
        );
      ''');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      release.complete();

      expect(await result, {'code': 'busy', 'first': 1});
      expect(browses, hasLength(1));
    });
  });
}
