import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/notifications/machine_control_review_dialog.dart';

void main() {
  Future<bool?> review(WidgetTester tester, String choice) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showMachineControlReview(
              context,
              pluginName: 'Skale',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Allow Skale to control the machine?'), findsOneWidget);
    await tester.tap(find.text(choice));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('Allow grants', (tester) async {
    expect(await review(tester, 'Allow'), isTrue);
  });

  testWidgets('Not now declines', (tester) async {
    expect(await review(tester, 'Not now'), isFalse);
  });
}
