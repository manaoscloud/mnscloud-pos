import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_pos/main.dart';
import 'package:mnscloud_pos/src/api/api_client.dart';
import 'package:mnscloud_pos/src/api/pos_api.dart';
import 'package:mnscloud_pos/src/brand/brand.dart';
import 'package:mnscloud_pos/src/state/pos_controller.dart';

void main() {
  test('the theme context becomes the POS brand; unsafe images are ignored', () {
    final brand = Brand.fromContext({
      'context': {
        'PageTitle': 'Loja Centro PDV',
        'LogoUrl': '/api/v1/public/theme/assets/0123456789abcdef0123456789abcdef',
        'FaviconUrl': 'javascript:alert(1)',
        'PrimaryColor': '#15803d',
      },
    })!;
    expect(brand.title, 'Loja Centro PDV');
    expect(brand.logoUrl, '/api/v1/public/theme/assets/0123456789abcdef0123456789abcdef');
    expect(brand.faviconUrl, isNull);
    expect(brand.primaryColor, const Color(0xFF15803D));
    expect(Brand.fromContext({'context': null}), isNull);
    expect(Brand.safeImageUrl('http://insecure.example/logo.png'), isNull);
    expect(Brand.safeImageUrl('https://cdn.example.com/logo.png'), 'https://cdn.example.com/logo.png');
    expect(Brand.parseHexColor('red'), isNull);
  });

  testWidgets('the sign-in card and the app title follow the brand', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = PosController(PosApi(ApiClient(baseUrl: 'http://invalid.local')));
    await tester.pumpWidget(PosApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('MNSCloud POS'), findsWidgets);

    controller.brand.value = const Brand(title: 'Loja Centro PDV', primaryColor: Color(0xFF7C3AED));
    await tester.pumpAndSettle();
    expect(find.text('Loja Centro PDV'), findsOneWidget);
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, 'Loja Centro PDV');
    expect(find.byKey(const Key('brandLogo')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
