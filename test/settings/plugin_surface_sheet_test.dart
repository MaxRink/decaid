import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/plugin_surface_sheet.dart';

void main() {
  final surface = Uri.parse(
    'http://localhost:8080/api/v1/plugins/p/setup?ui=1&surface=setup',
  );

  test('surface URLs carry embed, theme and lang', () {
    final themed = themedPluginSurfaceUri(
      surface,
      brightness: Brightness.dark,
      lang: 'de-DE',
    );
    expect(themed.path, surface.path);
    expect(themed.queryParameters, {
      'ui': '1',
      'surface': 'setup',
      'embed': '1',
      'theme': 'dark',
      'lang': 'de-DE',
    });
    expect(
      themedPluginSurfaceUri(
        surface,
        brightness: Brightness.light,
        embed: false,
      ).queryParameters,
      {'ui': '1', 'surface': 'setup', 'theme': 'light'},
    );
  });

  test('only a close message closes the sheet', () {
    expect(
      isPluginSurfaceCloseMessage([
        {'type': 'close'},
      ]),
      isTrue,
    );
    expect(isPluginSurfaceCloseMessage(const []), isFalse);
    expect(isPluginSurfaceCloseMessage(const ['close']), isFalse);
    expect(
      isPluginSurfaceCloseMessage([
        {'type': 'navigate'},
      ]),
      isFalse,
    );
  });

  test('navigation stays on the surface origin', () {
    expect(
      isSameSurfaceOrigin(surface, Uri.parse('http://localhost:8080/x')),
      isTrue,
    );
    expect(
      isSameSurfaceOrigin(surface, Uri.parse('http://localhost:8081/x')),
      isFalse,
    );
    expect(
      isSameSurfaceOrigin(surface, Uri.parse('https://example.com/')),
      isFalse,
    );
  });

  testWidgets('opens a themed sheet with a title and a close button', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showPluginSurface(
                context,
                surface,
                title: 'E64 setup',
                useSheet: true,
                webView: const Text('page'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final sheet = tester.widget<PluginSurfaceSheet>(
      find.byType(PluginSurfaceSheet),
    );
    expect(sheet.uri.queryParameters['embed'], '1');
    expect(sheet.uri.queryParameters['theme'], 'dark');
    expect(sheet.uri.queryParameters['lang'], 'en-US');
    expect(find.text('E64 setup'), findsOneWidget);
    expect(find.text('page'), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(PluginSurfaceSheet), findsNothing);
  });
}
