import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/mock_settings_service.dart';

class _WebUI extends Fake implements WebUIService {
  @override
  String serverPath() => '/';
}

class _Storage extends Fake implements WebUIStorage {}

void main() {
  late MockSettingsService store;
  late SettingsController settings;
  late RouterPlus router;

  setUp(() async {
    store = MockSettingsService();
    settings = SettingsController(store);
    await settings.loadSettings();
    router = Router().plus;
    SettingsHandler(
      controller: settings,
      service: _WebUI(),
      webUIStorage: _Storage(),
    ).addRoutes(router);
  });

  tearDown(() => settings.dispose());

  Future<Response> post(Object? value) async => router.call(
    Request(
      'POST',
      Uri.parse('http://localhost/api/v1/settings'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'keepServiceRunning': value}),
    ),
  );

  Future<Object?> read() async {
    final response = await router.call(
      Request('GET', Uri.parse('http://localhost/api/v1/settings')),
    );
    final body =
        jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    return body['keepServiceRunning'];
  }

  test('GET reports the default false', () async {
    expect(await read(), isFalse);
  });

  test('POST round-trips both ways and persists', () async {
    expect((await post(true)).statusCode, 200);
    expect(await read(), isTrue);
    expect(await store.keepServiceRunning(), isTrue);

    expect((await post(false)).statusCode, 200);
    expect(await read(), isFalse);
    expect(await store.keepServiceRunning(), isFalse);
  });

  test('POST rejects a non-boolean value', () async {
    final response = await post('yes');
    expect(response.statusCode, 400);
    expect(await store.keepServiceRunning(), isFalse);
  });
}
