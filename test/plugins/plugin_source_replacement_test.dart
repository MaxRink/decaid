import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_replacement.dart';
import 'package:reaprime/src/plugins/plugin_source.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/util/remote_update_report.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const id = 'managed.reaplugin';
  late Directory tempDir;
  late PluginLoaderService loader;
  late PluginSourceService service;

  List<int> archive({
    String version = '1.0.0',
    List<String> permissions = const ['log'],
    String marker = 'original',
  }) {
    final files = {
      'manifest.json': jsonEncode({
        'id': id,
        'author': 'Test',
        'name': 'Managed plugin',
        'description': 'Stores a token',
        'version': version,
        'apiVersion': 1,
        'permissions': permissions,
        'settings': {
          'token': {'type': 'string', 'secure': true},
        },
        'api': <Object>[],
      }),
      'plugin.js':
          '''
// $marker
function createPlugin() {
  return { id: "$id", onLoad() {} };
}
''',
    };
    final zip = Archive();
    files.forEach((path, content) {
      zip.addFile(ArchiveFile.string('repo-main/$path', content));
    });
    return ZipEncoder().encode(zip);
  }

  MockClient gitHub({
    String tag = 'v1.0.0',
    String commit = 'commit-1',
    required List<int> package,
  }) => MockClient((request) async {
    final url = request.url.toString();
    if (url.contains('/releases/latest') || url.contains('/releases/tags/')) {
      return http.Response(
        jsonEncode({
          'tag_name': tag,
          'name': tag,
          'assets': [
            {
              'name': 'plugin.zip',
              'browser_download_url': 'https://example.test/assets/plugin.zip',
            },
          ],
        }),
        200,
      );
    }
    if (url.contains('/commits/')) {
      return http.Response(jsonEncode({'sha': commit}), 200);
    }
    if (url.startsWith('https://example.test/') || url.contains('/archive/')) {
      return http.Response.bytes(package, 200);
    }
    return http.Response('not found: $url', 404);
  });

  Future<T> withGitHub<T>(
    Future<T> Function() body, {
    String tag = 'v1.0.0',
    String commit = 'commit-1',
    List<int>? package,
  }) => http.runWithClient(
    body,
    () => gitHub(tag: tag, commit: commit, package: package ?? archive()),
  );

  Future<bool> tokenIsSet() async =>
      ((await loader.pluginSettings(id))['token'] as Map)['isSet'] as bool;

  Future<void> installConfiguredRelease({String repo = 'acme/plugin'}) async {
    await withGitHub(() => service.installFromGitHubRelease(repo));
    await loader.savePluginSettings(id, {'token': 's3cret'});
  }

  Future<void> installConfiguredBranch() async {
    await withGitHub(() => service.installFromGitHubBranch('acme/plugin'));
    await loader.savePluginSettings(id, {'token': 's3cret'});
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('plugin_source_replacement');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => tempDir.path,
        );
    loader = PluginLoaderService(kvStore: FakeKeyValueStoreService());
    await loader.initialize();
    for (final plugin in loader.availablePlugins) {
      await loader.removePlugin(plugin.id);
    }
    service = PluginSourceService(loader);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await loader.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('GitHub release install over an installed plugin', () {
    test('an unattended install clears the stored secrets', () async {
      await installConfiguredRelease();

      await withGitHub(
        () => service.installFromGitHubRelease(
          'acme/plugin',
          approveReplacement: (_) => PluginReplacementDecision.unattended,
        ),
        tag: 'v1.1.0',
        package: archive(version: '1.1.0', marker: 'replacement'),
      );

      expect(loader.getPluginManifest(id)?.version, '1.1.0');
      expect(await tokenIsSet(), isFalse);
    });

    test('an install without any approver is refused', () async {
      await installConfiguredRelease();

      await expectLater(
        withGitHub(
          () => service.installFromGitHubRelease('acme/plugin'),
          tag: 'v1.1.0',
          package: archive(version: '1.1.0', marker: 'replacement'),
        ),
        throwsA(isA<PluginReplacementApprovalRequiredException>()),
      );
      expect(loader.getPluginManifest(id)?.version, '1.0.0');
      expect(await tokenIsSet(), isTrue);
    });

    test('an added permission is refused without approval', () async {
      await installConfiguredRelease();

      await expectLater(
        withGitHub(
          () => service.installFromGitHubRelease(
            'acme/plugin',
            approveReplacement: (_) => PluginReplacementDecision.unattended,
          ),
          tag: 'v1.1.0',
          package: archive(version: '1.1.0', permissions: ['log', 'api']),
        ),
        throwsA(
          isA<PluginReplacementApprovalRequiredException>().having(
            (e) => e.replacement.addedPermissions,
            'addedPermissions',
            ['api'],
          ),
        ),
      );
      expect(loader.getPluginManifest(id)?.permissions, hasLength(1));
      expect(await tokenIsSet(), isTrue);
    });

    test('an approving decision keeps secrets and grants', () async {
      await installConfiguredRelease();

      await withGitHub(
        () => service.installFromGitHubRelease(
          'acme/plugin',
          approveReplacement: (replacement) => PluginReplacementDecision(
            approvedPermissions: replacement.addedPermissions.toSet(),
            keepSecureSettings: true,
          ),
        ),
        tag: 'v1.1.0',
        package: archive(
          version: '1.1.0',
          permissions: ['log', 'api'],
          marker: 'replacement',
        ),
      );

      expect(loader.getPluginManifest(id)?.version, '1.1.0');
      expect(await tokenIsSet(), isTrue);
    });

    test('the same code from another repository is a new principal', () async {
      await installConfiguredRelease();
      PluginReplacement? reviewed;

      await withGitHub(
        () => service.installFromGitHubRelease(
          'mallory/plugin',
          approveReplacement: (replacement) {
            reviewed = replacement;
            return PluginReplacementDecision.unattended;
          },
        ),
      );

      expect(reviewed?.codeChanged, isFalse);
      expect(reviewed?.sourceChanged, isTrue);
      expect(await tokenIsSet(), isFalse);
      expect(service.sourceFor(id)?.repo, 'mallory/plugin');
    });
  });

  group('GitHub branch install over an installed plugin', () {
    test('an unattended install clears the stored secrets', () async {
      await installConfiguredBranch();

      await withGitHub(
        () => service.installFromGitHubBranch(
          'acme/plugin',
          approveReplacement: (_) => PluginReplacementDecision.unattended,
        ),
        commit: 'commit-2',
        package: archive(version: '1.0.1', marker: 'replacement'),
      );

      expect(service.sourceFor(id)?.commit, 'commit-2');
      expect(await tokenIsSet(), isFalse);
    });

    test('an added permission is refused without approval', () async {
      await installConfiguredBranch();

      await expectLater(
        withGitHub(
          () => service.installFromGitHubBranch(
            'acme/plugin',
            approveReplacement: (_) => PluginReplacementDecision.unattended,
          ),
          commit: 'commit-2',
          package: archive(version: '1.0.1', permissions: ['log', 'api']),
        ),
        throwsA(isA<PluginReplacementApprovalRequiredException>()),
      );
      expect(service.sourceFor(id)?.commit, 'commit-1');
    });
  });

  group('provenance follows the installed code', () {
    String localJs({String marker = 'local'}) =>
        '''
// $marker
function createPlugin() {
  return { id: "$id", onLoad() {} };
}
''';

    Map<String, dynamic> manifestJson(String version) => {
      'id': id,
      'author': 'Test',
      'name': 'Managed plugin',
      'description': 'Stores a token',
      'version': version,
      'apiVersion': 1,
      'permissions': ['log'],
      'settings': {
        'token': {'type': 'string', 'secure': true},
      },
      'api': <Object>[],
    };

    Future<({RemoteUpdateReport report, int repoRequests})> countedCheck({
      bool automatic = false,
    }) async {
      var repoRequests = 0;
      final client = gitHub(
        tag: 'v2.0.0',
        package: archive(version: '2.0.0', marker: 'upstream'),
      );
      final report = await http.runWithClient(
        () => service.checkForPluginUpdates(automatic: automatic),
        () => MockClient((request) {
          if (request.url.toString().contains('acme/plugin')) repoRequests++;
          return client.send(request).then(http.Response.fromStream);
        }),
      );
      return (report: report, repoRequests: repoRequests);
    }

    test('a source write makes the plugin local and untracked', () async {
      await installConfiguredRelease();
      await withGitHub(
        () => service.checkForPluginUpdates(),
        tag: 'v1.1.0',
        package: archive(version: '1.1.0', marker: 'replacement'),
      );
      expect(service.sourceFor(id)?.pendingUpdate, isNotNull);

      await loader.updatePluginSource(
        id,
        manifestJson: manifestJson('1.0.1'),
        pluginJs: localJs(),
        approveReplacement: (_) => PluginReplacementDecision.unattended,
      );

      final source = service.sourceFor(id)!;
      expect(source.kind, PluginSourceKind.localSource);
      expect(source.repo, isNull);
      expect(source.pendingUpdate, isNull);
      for (final automatic in [false, true]) {
        final check = await countedCheck(automatic: automatic);
        expect(check.report.results, isEmpty);
        expect(check.repoRequests, 0);
      }
      expect(loader.getPluginManifest(id)?.version, '1.0.1');
    });

    test('a GitHub reinstall records the repository again', () async {
      await installConfiguredRelease();
      await loader.updatePluginSource(
        id,
        manifestJson: manifestJson('1.0.1'),
        pluginJs: localJs(),
        approveReplacement: (_) => PluginReplacementDecision.unattended,
      );
      await loader.savePluginSettings(id, {'token': 's3cret'});
      PluginReplacement? reviewed;

      await withGitHub(
        () => service.installFromGitHubRelease(
          'acme/plugin',
          approveReplacement: (replacement) {
            reviewed = replacement;
            return PluginReplacementDecision.unattended;
          },
        ),
        tag: 'v1.1.0',
        package: archive(version: '1.1.0'),
      );

      expect(reviewed?.sourceChanged, isTrue);
      final source = service.sourceFor(id)!;
      expect(source.kind, PluginSourceKind.githubRelease);
      expect(source.repo, 'acme/plugin');
      final check = await countedCheck();
      expect(check.repoRequests, greaterThan(0));
      expect(check.report.results.single.item, id);
    });

    test('a failed source write keeps the GitHub provenance', () async {
      await installConfiguredRelease();
      await loader.enablePlugin(id);

      await expectLater(
        loader.updatePluginSource(
          id,
          manifestJson: manifestJson('1.0.1'),
          pluginJs: 'throw new Error("broken");',
          approveReplacement: (_) => PluginReplacementDecision.unattended,
        ),
        throwsA(anything),
      );

      final source = service.sourceFor(id)!;
      expect(source.kind, PluginSourceKind.githubRelease);
      expect(source.repo, 'acme/plugin');
      expect(await tokenIsSet(), isTrue);
    });

    test('a local ZIP over a GitHub install is untracked too', () async {
      await installConfiguredRelease();
      final zip = File('${tempDir.path}/local.zip')
        ..writeAsBytesSync(archive(version: '1.0.1', marker: 'zip'));

      await service.installFromZip(
        zip.path,
        approveReplacement: (_) => PluginReplacementDecision.unattended,
      );

      expect(service.sourceFor(id)?.kind, PluginSourceKind.localZip);
      final check = await countedCheck();
      expect(check.report.results, isEmpty);
      expect(check.repoRequests, 0);
      expect(await tokenIsSet(), isFalse);
    });
  });

  group('update checks', () {
    test(
      'a new release of a plugin holding secrets waits for review',
      () async {
        await installConfiguredRelease();

        final report = await withGitHub(
          () => service.checkForPluginUpdates(),
          tag: 'v1.1.0',
          package: archive(version: '1.1.0', marker: 'replacement'),
        );

        expect(
          report.results.single.status,
          RemoteUpdateStatus.pendingApproval,
        );
        expect(loader.getPluginManifest(id)?.version, '1.0.0');
        expect(await tokenIsSet(), isTrue);
        final pending = service.sourceFor(id)!.pendingUpdate!;
        expect(pending.version, '1.1.0');
        expect(pending.addedPermissions, isEmpty);
        expect(pending.handsOverSecureSettings, isTrue);
      },
    );

    test('the background check holds a plugin holding secrets', () async {
      await installConfiguredRelease();

      final report = await withGitHub(
        () => service.checkForPluginUpdates(automatic: true),
        tag: 'v1.1.0',
        package: archive(version: '1.1.0', marker: 'replacement'),
      );

      expect(report.results.single.status, RemoteUpdateStatus.pendingApproval);
      expect(await tokenIsSet(), isTrue);
    });

    test('a branch install is not moved by the background check', () async {
      await installConfiguredBranch();

      final report = await withGitHub(
        () => service.checkForPluginUpdates(automatic: true),
        commit: 'commit-2',
        package: archive(version: '1.0.1', marker: 'replacement'),
      );

      expect(report.results, isEmpty);
      expect(service.sourceFor(id)?.commit, 'commit-1');
    });

    test('a release without code changes keeps its secrets', () async {
      await installConfiguredRelease();

      final report = await withGitHub(
        () => service.checkForPluginUpdates(automatic: true),
        tag: 'v1.1.0',
        package: archive(version: '1.1.0'),
      );

      expect(report.results.single.status, RemoteUpdateStatus.updated);
      expect(loader.getPluginManifest(id)?.version, '1.1.0');
      expect(await tokenIsSet(), isTrue);
    });

    test('a plugin without secrets still updates on its own', () async {
      await withGitHub(() => service.installFromGitHubRelease('acme/plugin'));

      final report = await withGitHub(
        () => service.checkForPluginUpdates(automatic: true),
        tag: 'v1.1.0',
        package: archive(version: '1.1.0', marker: 'replacement'),
      );

      expect(report.results.single.status, RemoteUpdateStatus.updated);
    });

    test('approval decides whether the secrets are kept', () async {
      await installConfiguredRelease();
      await withGitHub(
        () => service.checkForPluginUpdates(),
        tag: 'v1.1.0',
        package: archive(version: '1.1.0', marker: 'replacement'),
      );

      await withGitHub(
        () => service.approvePendingUpdate(id, keepSecureSettings: true),
        tag: 'v1.1.0',
        package: archive(version: '1.1.0', marker: 'replacement'),
      );
      expect(loader.getPluginManifest(id)?.version, '1.1.0');
      expect(await tokenIsSet(), isTrue);

      await withGitHub(
        () => service.checkForPluginUpdates(),
        tag: 'v1.2.0',
        package: archive(version: '1.2.0', marker: 'second'),
      );
      await withGitHub(
        () => service.approvePendingUpdate(id),
        tag: 'v1.2.0',
        package: archive(version: '1.2.0', marker: 'second'),
      );
      expect(loader.getPluginManifest(id)?.version, '1.2.0');
      expect(await tokenIsSet(), isFalse);
    });
  });
}
