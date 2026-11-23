import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/advanced_page.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_settings_service.dart';

void main() {
  const label = 'Keep Decaid running in the background';

  Future<(SettingsController, MockSettingsService)> pumpPage(
    WidgetTester tester, {
    List<bool>? batteryPrompts,
  }) async {
    final service = MockSettingsService();
    final controller = SettingsController(service);
    addTearDown(controller.dispose);
    await controller.loadSettings();
    await tester.pumpWidget(
      ShadApp(
        home: AdvancedPage(
          controller: controller,
          requestBatteryOptimizationExemption: () async {
            batteryPrompts?.add(true);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (controller, service);
  }

  testWidgets(
    'toggle persists both ways and prompts for the battery exemption only '
    'when enabling',
    (tester) async {
      final prompts = <bool>[];
      final (controller, service) = await pumpPage(
        tester,
        batteryPrompts: prompts,
      );

      final toggle = find.widgetWithText(ShadSwitch, label);
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<ShadSwitch>(toggle).value, isFalse);
      expect(
        find.textContaining(
          'Keeps the API, plugins and integrations available while the '
          'machine is off',
        ),
        findsOneWidget,
      );

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(controller.keepServiceRunning, isTrue);
      expect(await service.keepServiceRunning(), isTrue);
      expect(tester.widget<ShadSwitch>(toggle).value, isTrue);
      expect(prompts, hasLength(1));

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(controller.keepServiceRunning, isFalse);
      expect(await service.keepServiceRunning(), isFalse);
      expect(prompts, hasLength(1));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('toggle is hidden off Android', (tester) async {
    await pumpPage(tester);
    expect(find.text(label), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
