import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_pos/main.dart';
import 'package:mnscloud_pos/src/api/api_client.dart';
import 'package:mnscloud_pos/src/api/pos_api.dart';
import 'package:mnscloud_pos/src/state/pos_controller.dart';

/// The sign-in card must render its fields in every supported locale. Without the Material
/// localization delegates a pt/es browser turned each TextField into a 100000 px grey error box
/// and pushed the sign-in button off screen.
void main() {
  for (final (locale, button) in [
    (const Locale('pt', 'BR'), 'Entrar'),
    (const Locale('es', 'ES'), 'Ingresar'),
    (const Locale('en', 'US'), 'Sign in'),
  ]) {
    testWidgets('sign-in renders fields and button in $locale', (tester) async {
      tester.platformDispatcher.localesTestValue = [locale];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final controller = PosController(PosApi(ApiClient(baseUrl: 'http://invalid.local')));
      await tester.pumpWidget(PosApp(controller: controller));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      expect(find.byType(TextField), findsNWidgets(2));
      final signIn = find.widgetWithText(FilledButton, button);
      expect(signIn, findsOneWidget);
      expect(tester.getBottomLeft(signIn).dy, lessThan(800));
    });
  }
}
