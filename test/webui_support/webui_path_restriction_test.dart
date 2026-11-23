import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

import '../helpers/mock_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late WebUIStorage storage;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('webui_path_restriction');
    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    storage = WebUIStorage(settings)
      ..debugInitWithWebUIDir(Directory('${root.path}/web-ui'));
    Directory('${root.path}/web-ui/my-skin/assets').createSync(recursive: true);
    Directory('${root.path}/elsewhere').createSync();
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('a skin folder inside the skin storage is servable', () {
    expect(storage.containsSkinPath('${root.path}/web-ui/my-skin'), isTrue);
    expect(
      storage.containsSkinPath('${root.path}/web-ui/my-skin/assets'),
      isTrue,
    );
  });

  test('anything outside the skin storage is refused', () {
    for (final path in [
      '${root.path}/elsewhere',
      '${root.path}/web-ui',
      '${root.path}/web-ui/../elsewhere',
      '${root.path}/web-ui/missing',
      '/',
      '',
    ]) {
      expect(storage.containsSkinPath(path), isFalse, reason: path);
    }
  });

  test('a symlink out of the skin storage is refused', () {
    Link('${root.path}/web-ui/escape').createSync('${root.path}/elsewhere');
    expect(storage.containsSkinPath('${root.path}/web-ui/escape'), isFalse);
  });
}
