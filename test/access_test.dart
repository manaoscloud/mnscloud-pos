import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_pos/main.dart';
import 'package:mnscloud_pos/src/api/api_client.dart';
import 'package:mnscloud_pos/src/api/pos_api.dart';
import 'package:mnscloud_pos/src/brand/brand.dart';
import 'package:mnscloud_pos/src/state/pos_controller.dart';

PosController _controller() => PosController(PosApi(ApiClient(baseUrl: 'http://invalid.local')));

Future<void> _pump(WidgetTester tester, PosController controller, Size size) async {
  tester.platformDispatcher.localesTestValue = [const Locale('pt', 'BR')];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(PosApp(controller: controller));
  await tester.pumpAndSettle();
}

void main() {
  test('the theme context carries the POS login appearance; links are https only', () {
    final brand = Brand.fromContext({
      'context': {
        'PageTitle': 'Loja Centro',
        'LoginAppearance': {
          'layout': 'compact',
          'texts': {
            'pt-BR': {'title': 'Bem-vindo ao caixa', 'subtitle': ' '},
          },
        },
      },
    })!;
    expect(brand.login['layout'], 'compact');
    expect(brand.loginText('pt-BR', 'title'), 'Bem-vindo ao caixa');
    expect(brand.loginText('pt-BR', 'subtitle'), isNull);
    expect(brand.loginText('en-US', 'title'), isNull);
    expect(Brand.safeLink('https://example.com/help'), 'https://example.com/help');
    expect(Brand.safeLink('javascript:alert(1)'), isNull);
    expect(Brand.safeLink('https://user:pass@example.com/'), isNull);
    expect(
      Brand.fromContext({
        'context': {'PageTitle': 'X'},
      })!.login,
      isEmpty,
    );
  });

  testWidgets('wide screens show the brand panel with the POS defaults and no footer links', (tester) async {
    final controller = _controller();
    await _pump(tester, controller, const Size(1440, 900));
    expect(find.text('Seu caixa.\nPronto para vender.'), findsOneWidget);
    expect(find.text('Entre no seu caixa'), findsOneWidget);
    expect(find.text('Privacidade'), findsNothing);
    expect(find.text('Termos de uso'), findsNothing);
    expect(find.byKey(const Key('signOut')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Themes copy, compact layout and links replace the defaults', (tester) async {
    final controller = _controller();
    controller.brand.value = const Brand(
      title: 'Loja Centro',
      login: {
        'layout': 'compact',
        'privacyUrl': 'https://example.com/privacy',
        'termsUrl': 'javascript:alert(1)',
        'texts': {
          'pt-BR': {'title': 'Bem-vindo ao caixa'},
        },
      },
    );
    await _pump(tester, controller, const Size(1440, 900));
    expect(find.text('Bem-vindo ao caixa'), findsOneWidget);
    expect(find.text('Seu caixa.\nPronto para vender.'), findsNothing);
    expect(find.text('Privacidade'), findsOneWidget);
    expect(find.text('Termos de uso'), findsNothing);
    expect(find.text('Loja Centro'), findsOneWidget);
  });

  testWidgets('the password can be shown and the language changes without losing the e-mail', (tester) async {
    final controller = _controller();
    await _pump(tester, controller, const Size(390, 844));
    await tester.enterText(find.byKey(const Key('signInEmail')), 'ana@example.com');
    TextField password() => tester.widget<TextField>(find.byKey(const Key('signInPassword')));
    expect(password().obscureText, isTrue);
    await tester.tap(find.byKey(const Key('togglePassword')));
    await tester.pump();
    expect(password().obscureText, isFalse);

    await tester.tap(find.byKey(const Key('accessLanguage')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English (US)').last);
    await tester.pumpAndSettle();
    expect(controller.locale.value, const Locale('en', 'US'));
    expect(find.text('Sign in to your register'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('signInEmail'))).controller!.text, 'ana@example.com');
    expect(tester.takeException(), isNull);
  });
}
